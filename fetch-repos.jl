using Downloads, Printf, Dates
using Downloads: download


function fetch_repo(url, name; outdir)
    println(stderr, "FETCH: ", (name, url, outdir))
    mkpath(outdir)

    outfile = @sprintf "%s/%s.xml" outdir name
    if isfile(outfile)
        println(stderr, "$outfile already exists")
    else
        try
            download(url, outfile)
        catch e
            println(stderr, "ERROR: ", (name, url, outdir))
            println(stderr, "ERROR: ", e)
        end
    end
end

#=function main0(url_, n; 
        outdir = basename(url_)
    )
    mkpath(outdir)

    for i in 1:n
        outfile = @sprintf "%s/%05d.html" outdir i
        url = string(url_, "/", i, "?mode=full")
        if isfile(outfile)
            println(stderr, "$outfile already exists")
        else
            try

                download(url, outfile)
            catch e 
                @info i, url, e
            end
        end
    end

    sleep(1.1)
end
=#

#main("https://infotec.repositorioinstitucional.mx/jspui/handle/1027", 1000)
#main("https://cide.repositorioinstitucional.mx/jspui/handle/1011", 2000)
#main("https://ciesas.repositorioinstitucional.mx/jspui/handle/1015", 2000)
#main("http://ciatec.repositorioinstitucional.mx/jspui/handle/1019", 1000)
#main(

repo0(url, name) = string(url, "?verb=ListRecords&metadataPrefix=oai_dc") => name
repo1(name) = "https://$name.repositorioinstitucional.mx/oai/request?verb=ListRecords&metadataPrefix=oai_dc" => name

repolist = [ # https://www.repositorionacionalcti.mx/directory
         repo1("infotec"), repo1("cide"), repo1("ciesas"), repo1("ciatec"), repo1("ipicyt"),
         repo1("colsan"), repo1("inecol"), repo1("cicy"), repo1("mora"), repo1("ciqa"),
         repo1("ciatej"), repo1("inaoe"), repo1("flacso"), repo1("comimsa"), repo1("cimav"),
         repo1("cicese"), repo1("cidesi"), repo1("cibnor"), repo1("colmich"), repo1("centrogeo"),
         repo1("cio"), repo1("cimat"), repo1("ecosur"), repo1("ciad"), repo1("colef"),
         repo1("ciateq"), 
         repo0("https://ninive.uaslp.mx/oai/conacyt", "uaslp"),
         repo0("https://repositorio.inmegen.gob.mx/oai2d/", "inmegen"),
         repo0("http://biblos.ucol.mx/oai/conacyt", "ucol"),
         repo0("http://ri.uacj.mx/vufind/OAI/conacyt", "uacj"),
         repo0("https://riuat.uat.edu.mx/oai/conacyt", "uat"),
         repo0("http://repositorio.imta.mx/oai/request", "imta"),
         repo0("http://aramara.uan.mx:8080/oai/conacyt", "uan"),
         repo0("http://repositorio.pediatria.gob.mx:8180/oai/request", "padiatria"),
         repo0("http://www.repositorio.ugto.mx/oai/public", "ugto"),
         repo0("http://repositorio.inprf.gob.mx/oai/request", "inprf"),
         repo0("http://ricaxcan.uaz.edu.mx/oai/conacyt", "uaz"),
         repo0("http://riacti.uanl.mx/cgi/oai2", "uanl"),
         repo0("http://zaloamati.azc.uam.mx/oai/conacyt", "uam"),
         repo0("https://repositorio.colmex.mx/conacyt/oai/oai2.php", "colmex"),
         repo0("https://ri.ujat.mx/oai/request", "ujat"),
         repo0("http://repositorio.insp.mx:8080/oai/request", "insp"),
         repo0("http://riaa.uaem.mx:8080/oai/request", "uaem"),
         repo0("http://ri.atmosfera.unam.mx:8081/geonetwork/srv/spa/oaipmh", "unam-atmosfera"),
         repo0("https://repositorio.tec.mx/oai/conacyt", "itesm"),
         repo0("http://132.248.192.241:8080/oai/request", "unam-educacion"),
         repo0("http://bgtq.ajusco.upn.mx:8080/oai/request", "upna"),
         repo0("http://ri.uaemex.mx/oai/conacyt", "uaemex"),
         repo0("http://ilitia.cua.uam.mx:8080/oai/request", "uam-cuajimalpa"),
         repo0("https://repositorio.uaaan.mx/oai/request", "uaaan"),
         repo0("http://ru.micisan.unam.mx/oai/request", "unamic-micisan"),
         repo0("http://187.216.227.29:8080/oai/conacyt", "up-puebla"),
         repo0("https://scripta.up.edu.mx/oai/conacyt", "up-scripta"),
         repo0("http://rep.uabcs.mx/oai/request", "uabcs"),
         repo0("https://xogi.ler.uam.mx:8080/server/oai/request", "uam-lerma"),
         repo0("http://repositorio.ineel.mx/oai/request", "ineel"),
         repo0("http://colposdigital.colpos.mx:8080/oai/conacyt", "colpos"),
         repo0("http://risisbi.uqroo.mx/oai/conacyt", "uqroo"),
         repo0("http://ri.ibero.mx/oai/conacyt", "ibero"),
         repo0("http://www.repositorioinstitucional.uson.mx/oai/conacyt", "uson"),
         repo0("http://www.redaec.unam.mx/oaiData", "unam-redaec"),
         repo0("http://rdu.iquimica.unam.mx/oai/public", "unam-iquimica"),
         repo0("http://repositorio.udlap.mx/oai/conacyt", "udlap"),
         repo0("http://ru.iibi.unam.mx/oai/openaire", "unam-iibi"),
         repo0("https://openaire.cimmyt.org:443/datacite", "cimmyt-data"),
         repo0("https://openaire.cimmyt.org:443/oai/", "cimmyt-mm"),
         repo0("http://repositorio.unach.mx:8080/oai/request", "unach"),
         repo0("http://rigeofisica.ssn.unam.mx/oai/request", "unam-ssn"),
         repo0("http://www.cienciasinaloa.ipn.mx/oai/request", "ipn-sinaloa"),
         repo0("http://redi.uady.mx/oai/openaire", "uady"),
         repo0("http://repositorio.inger.gob.mx/oai/request", "inger"),
         repo0("http://repositorio.upiicsa.ipn.mx/oai/request", "ipn-upiicsa"),
         repo0("http://bindani.izt.uam.mx/catalog/oai", "uam-izt"),
         repo0("http://metadata.icmyl.unam.mx/oai/request", "unam-icmyl"),
         repo0("http://www.riimas.unam.mx/oai/request", "unam-iimas"),
         repo0("http://132.248.34.155:8088/oai/provider", "ccg"),
         repo0("http://reini.utcv.edu.mx/oai/request", "utcv"),
         repo0("http://rigeotermia.geofisica.unam.mx/oai/request", "unam-geofisica"),
         repo0("http://mexculture.citedi.mx/oai/request", "ipn-cideti"),
         repo0("https://ru.iztacala.unam.mx/oai-pmh-repository/request", "unam-iztacala"),
         repo0("http://ru.ameyalli.dgdc.unam.mx/oai/request", "unam-dgdc"),
         repo0("http://www.rice.unam.mx:8080/oai", "unam-rice"),
         repo0("http://ri-ng.uaq.mx/oai/request/", "uaq"),
         repo0("http://rdcb.cbg.ipn.mx/oai/public", "ipn-cbg"),
         repo0("http://bibliotecavirtual.dgb.umich.mx:8083/oai/request", "umich"),
         repo0("https://repositorioinstitucional.buap.mx/oai/conacyt", "buap"),
         repo0("http://hermes2.ifc.unam.mx/oai/request", "unam-ifc"),
         repo0("http://repositorio.lania.mx/oai/conacyt", "lania"),
         repo0("http://ri.uagro.mx/oai/conacyt", "uagro"),
         repo0("http://literatura.ciidiroaxaca.ipn.mx/oai/request", "ipn-ciidir-literatura"),
         repo0("http://colecciones.ciidiroaxaca.ipn.mx/oai/request", "ipn-ciidir-colecciones"),
         repo0("http://ru.atheneadigital.filos.unam.mx/oai/openaire", "unam-filos"),
         repo0("http://repositorio.utm.mx/oai/conacyt", "utmixteca"),
         repo0("https://ru.historicas.unam.mx/oai/conacyt", "unam-historicas"),
         repo0("http://ru.facmed.unam.mx/oai/openaire", "unam-facmed"),
         repo0("http://www.repositorio.unacar.mx/oai/conacyt", "unacar"),
         repo0("https://repositorio.colson.edu.mx/oai/conacyt", "colson"),
         repo0("https://rinacional.tecnm.mx/oai/conacyt", "tecnm"),
         repo0("https://ru.tic.unam.mx/oai/conacyt", "unam-tic"),
         repo0("http://uniciencias.fciencias.unam.mx/oai/request", "unam-fciencias"),
         repo0("https://repositorio.unicach.mx/oai/conacyt", "unicach"),
         repo0("https://cenoteando.org/oai/request", "unam-cenoteando"),
         repo0("http://rigeofisica.ssn.unam.mx/oai/literatura", "unam-ssn-literatura"),
         repo0("http://www.repositorio.unadmexico.mx:8080/oai/request", "unad"),
         ]

#outdir = string("repositorios/metadata-", Dates.format(now(), "YYYY-mm-dd"))
outdir = "repositorios/metadata-2024-05-29"

for (url, name) in repolist
    fetch_repo(url, name; outdir)
end
